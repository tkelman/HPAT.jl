#=
Copyright (c) 2016, Intel Corporation
All rights reserved.

Redistribution and use in source and binary forms, with or without 
modification, are permitted provided that the following conditions are met:
- Redistributions of source code must retain the above copyright notice, 
  this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, 
  this list of conditions and the following disclaimer in the documentation 
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE 
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF 
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS 
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) 
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF 
THE POSSIBILITY OF SUCH DAMAGE.
=# 

module CGenPatternMatch

import ParallelAccelerator
import ParallelAccelerator.ParallelIR.DelayedFunc
import CompilerTools.DebugMsg
using CompilerTools.LambdaHandling
using CompilerTools.Helper
DebugMsg.init()

#using Debug

include("cgen-hpat-pattern-match-daal.jl")

function pattern_match_call_dist_init(f::TopNode)
    if f.name==:hps_dist_init
        return ";"#"MPI_Init(0,0);"
    else
        return ""
    end
end

function pattern_match_call_dist_init(f::Any)
    return ""
end

function pattern_match_reduce_sum(reductionFunc::DelayedFunc)
    if reductionFunc.args[1][1].args[2].args[1]==TopNode(:add_float) || reductionFunc.args[1][1].args[2].args[1]==TopNode(:add_int)
        return true
    end
    return false
end

function pattern_match_call_dist_reduce(f::TopNode, var::SymbolNode, reductionFunc::DelayedFunc, output::Symbol)
    if f.name==:hps_dist_reduce
        mpi_type = ""
        if var.typ==Float64
            mpi_type = "MPI_DOUBLE"
        elseif var.typ==Float32
            mpi_type = "MPI_FLOAT"
        elseif var.typ==Int32
            mpi_type = "MPI_INT"
        elseif var.typ==Int64
            mpi_type = "MPI_LONG_LONG_INT"
        else
            throw("CGen unsupported MPI reduction type")
        end

        mpi_func = ""
        if pattern_match_reduce_sum(reductionFunc)
            mpi_func = "MPI_SUM"
        else
            throw("CGen unsupported MPI reduction function")
        end
                
        s="MPI_Reduce(&$(var.name), &$output, 1, $mpi_type, $mpi_func, 0, MPI_COMM_WORLD);"
        # debug print for 1D_sum
        #s*="printf(\"len %d start %d end %d\\n\", parallel_ir_save_array_len_1_1, __hpat_loop_start_2, __hpat_loop_end_3);\n"
        return s
    else
        return ""
    end
end

function pattern_match_call_dist_reduce(f::Any, v::Any, rf::Any, o::Any)
    return ""
end

function pattern_match_call_dist_allreduce(f::TopNode, var::SymAllGen, reductionFunc::TopNode, output::SymAllGen, size::Symbol)
    if f.name==:hps_dist_allreduce
        mpi_type = ""
        var = toSymGen(var)
        c_var = ParallelAccelerator.CGen.from_expr(var)
        c_output = ParallelAccelerator.CGen.from_expr(output)
        var_typ = ParallelAccelerator.CGen.getSymType(var)
        is_array =  var_typ<:Array
        if is_array
            var_typ = eltype(var_typ)
            c_var *= ".data"
            c_output *= ".data"
        else
            c_var = "&"*c_var
            c_output = "&"*c_output
        end
        if var_typ==Float64
            mpi_type = "MPI_DOUBLE"
        elseif var_typ==Float32
            mpi_type = "MPI_FLOAT"
        elseif var_typ==Int32
            mpi_type = "MPI_INT"
        elseif var_typ==Int64
            mpi_type = "MPI_LONG_LONG_INT"
        else
            println("reduction type ", var_typ)
            throw("CGen unsupported MPI reduction type")
        end

        mpi_func = ""
        if reductionFunc.name == :add_float
            mpi_func = "MPI_SUM"
        else
            throw("CGen unsupported MPI reduction function")
        end
                
        s="MPI_Allreduce($c_var, $c_output, $size, $mpi_type, $mpi_func, MPI_COMM_WORLD);"
        # debug print for 1D_sum
        #s*="printf(\"len %d start %d end %d\\n\", parallel_ir_save_array_len_1_1, __hpat_loop_start_2, __hpat_loop_end_3);\n"
        return s
    else
        return ""
    end
end

function pattern_match_call_dist_allreduce(f::Any, v::Any, rf::Any, o::Any, s::Any)
    return ""
end

function pattern_match_call_dist_bcast(f::Symbol, var::SymAllGen, size::Symbol)
    if f==:__hpat_dist_broadcast
        mpi_type = ""
        var = toSymGen(var)
        c_var = ParallelAccelerator.CGen.from_expr(var)
        var_typ = ParallelAccelerator.CGen.getSymType(var)
        is_array =  var_typ<:Array
        if is_array
            var_typ = eltype(var_typ)
            c_var *= ".data"
        else
            c_var = "&"*c_var
        end
        if var_typ==Float64
            mpi_type = "MPI_DOUBLE"
        elseif var_typ==Float32
            mpi_type = "MPI_FLOAT"
        elseif var_typ==Int32
            mpi_type = "MPI_INT"
        elseif var_typ==Int64
            mpi_type = "MPI_LONG_LONG_INT"
        else
            println("reduction type ", var_typ)
            throw("CGen unsupported MPI broadcast type")
        end
                
        s="MPI_Bcast($c_var, $size, $mpi_type, 0, MPI_COMM_WORLD);"
        return s
    else
        return ""
    end
end

function pattern_match_call_dist_bcast(f::Any, v::Any, rf::Any)
    return ""
end

"""
Generate code for HDF5 file open
"""
function pattern_match_call_data_src_open(f::Symbol, id::Int, data_var::Union{SymAllGen,AbstractString}, file_name::Union{SymAllGen,AbstractString}, arr::Symbol)
    s = ""
    if f==:__hpat_data_source_HDF5_open
        num::AbstractString = string(id)
    
        s = "hid_t plist_id_$num = H5Pcreate(H5P_FILE_ACCESS);\n"
        s *= "assert(plist_id_$num != -1);\n"
        s *= "herr_t ret_$num;\n"
        s *= "hid_t file_id_$num;\n"
        s *= "ret_$num = H5Pset_fapl_mpio(plist_id_$num, MPI_COMM_WORLD, MPI_INFO_NULL);\n"
        s *= "assert(ret_$num != -1);\n"
        s *= "file_id_$num = H5Fopen("*ParallelAccelerator.CGen.from_expr(file_name)*", H5F_ACC_RDONLY, plist_id_$num);\n"
        s *= "assert(file_id_$num != -1);\n"
        s *= "ret_$num = H5Pclose(plist_id_$num);\n"
        s *= "assert(ret_$num != -1);\n"
        s *= "hid_t dataset_id_$num;\n"
        s *= "dataset_id_$num = H5Dopen2(file_id_$num, "*ParallelAccelerator.CGen.from_expr(data_var)*", H5P_DEFAULT);\n"
        s *= "assert(dataset_id_$num != -1);\n"
    end
    return s
end

function pattern_match_call_data_src_open(f::Any, v::Any, rf::Any, o::Any, arr::Any)
    return ""
end

"""
Generate code for text file open (no variable name input)
"""
function pattern_match_call_data_src_open(f::Symbol, id::Int, file_name::Union{SymAllGen,AbstractString}, arr::Symbol)
    s = ""
    if f==:__hpat_data_source_TXT_open
        num::AbstractString = string(id)
        file_name_str::AbstractString = ParallelAccelerator.CGen.from_expr(file_name)
        s = """
            MPI_File dsrc_txt_file_$num;
            int ierr_$num = MPI_File_open(MPI_COMM_WORLD, $file_name_str, MPI_MODE_RDONLY, MPI_INFO_NULL, &dsrc_txt_file_$num);
            assert(ierr_$num==0);
            """
    end
    return s
end

function pattern_match_call_data_src_open(f::Any, rf::Any, o::Any, arr::Any)
    return ""
end



function pattern_match_call_data_src_read(f::Symbol, id::Int, arr::Symbol, start::Symbol, count::Symbol)
    s = ""
    num::AbstractString = string(id)
    
    if f==:__hpat_data_source_HDF5_read
        data_typ = eltype(ParallelAccelerator.CGen.getSymType(arr))
        h5_typ = ""
        if data_typ==Float64
            h5_typ = "H5T_NATIVE_DOUBLE"
        elseif data_typ==Float32
            h5_typ = "H5T_NATIVE_FLOAT"
        elseif data_typ==Int32
            h5_typ = "H5T_NATIVE_INT"
        elseif data_typ==Int64
            h5_typ = "H5T_NATIVE_LLONG"
        else
            println("g5 data type ", data_typ)
            throw("CGen unsupported HDF5 data type")
        end
        
        # assuming 1st dimension is partitined
        s =  "hsize_t CGen_HDF5_start_$num[data_ndim_$num];\n"
        s *= "hsize_t CGen_HDF5_count_$num[data_ndim_$num];\n"
        s *= "CGen_HDF5_start_$num[0] = $start;\n"
        s *= "CGen_HDF5_count_$num[0] = $count;\n"
        s *= "for(int i_CGen_dim=1; i_CGen_dim<data_ndim_$num; i_CGen_dim++) {\n"
        s *= "CGen_HDF5_start_$num[i_CGen_dim] = 0;\n"
        s *= "CGen_HDF5_count_$num[i_CGen_dim] = space_dims_$num[i_CGen_dim];\n"
        s *= "}\n"
        #s *= "std::cout<<\"read size \"<<CGen_HDF5_start_$num[0]<<\" \"<<CGen_HDF5_count_$num[0]<<\" \"<<CGen_HDF5_start_$num[1]<<\" \"<<CGen_HDF5_count_$num[1]<<std::endl;\n"
        s *= "ret_$num = H5Sselect_hyperslab(space_id_$num, H5S_SELECT_SET, CGen_HDF5_start_$num, NULL, CGen_HDF5_count_$num, NULL);\n"
        s *= "assert(ret_$num != -1);\n"
        s *= "hid_t mem_dataspace_$num = H5Screate_simple (data_ndim_$num, CGen_HDF5_count_$num, NULL);\n"
        s *= "assert (mem_dataspace_$num != -1);\n"
        s *= "hid_t xfer_plist_$num = H5Pcreate (H5P_DATASET_XFER);\n"
        s *= "assert(xfer_plist_$num != -1);\n"
        s *= "double h5_read_start_$num = MPI_Wtime();\n"
        s *= "ret_$num = H5Dread(dataset_id_$num, $h5_typ, mem_dataspace_$num, space_id_$num, xfer_plist_$num, $arr.getData());\n"
        s *= "assert(ret_$num != -1);\n"
        #s*="if(__hpat_node_id==__hpat_num_pes/2) printf(\"h5 read %lf\\n\", MPI_Wtime()-h5_read_start_$num);\n"
        s *= ";\n"
    elseif f==:__hpat_data_source_TXT_read
        # assuming 1st dimension is partitined
        data_typ = eltype(ParallelAccelerator.CGen.getSymType(arr))
        t_typ = ParallelAccelerator.CGen.toCtype(data_typ)
        
        s = """
            int64_t CGen_txt_start_$num = $start;
            int64_t CGen_txt_count_$num = $count;
            int64_t CGen_txt_end_$num = $start+$count;
            
            
            // std::cout<<"rank: "<<__hpat_node_id<<" start: "<<CGen_txt_start_$num<<" end: "<<CGen_txt_end_$num<<" columnSize: "<<CGen_txt_col_size_$num<<std::endl;
            // if data needs to be sent left
            // still call MPI_Send if first character is new line
            int64_t CGen_txt_left_send_size_$num = 0;
            int64_t CGen_txt_tmp_curr_start_$num = CGen_txt_curr_start_$num;
            if(CGen_txt_start_$num>CGen_txt_curr_start_$num)
            {
                while(CGen_txt_tmp_curr_start_$num!=CGen_txt_start_$num)
                {
                    while(CGen_txt_buffer_$num[CGen_txt_left_send_size_$num]!=\'\\n\') 
                        CGen_txt_left_send_size_$num++;
                    CGen_txt_left_send_size_$num++; // account for \n
                    CGen_txt_tmp_curr_start_$num++;
                }
            }
            MPI_Request CGen_txt_MPI_request1_$num, CGen_txt_MPI_request2_$num;
            MPI_Status CGen_txt_MPI_status_$num;
            // send left
            if(__hpat_node_id!=0)
            {
                MPI_Isend(&CGen_txt_left_send_size_$num, 1, MPI_LONG_LONG_INT, __hpat_node_id-1, 0, MPI_COMM_WORLD, &CGen_txt_MPI_request1_$num);
                MPI_Isend(CGen_txt_buffer_$num, CGen_txt_left_send_size_$num, MPI_CHAR, __hpat_node_id-1, 1, MPI_COMM_WORLD, &CGen_txt_MPI_request2_$num);
                // std::cout<<"rank: "<<__hpat_node_id<<" sent left "<<CGen_txt_left_send_size_$num<<std::endl;
            }
            
            char* CGen_txt_right_buff_$num = NULL;
            int64_t CGen_txt_right_recv_size_$num = 0;
            // receive from right
            if(__hpat_node_id!=__hpat_num_pes-1)
            {
                MPI_Recv(&CGen_txt_right_recv_size_$num, 1, MPI_LONG_LONG_INT, __hpat_node_id+1, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                CGen_txt_right_buff_$num = new char[CGen_txt_right_recv_size_$num];
                MPI_Recv(CGen_txt_right_buff_$num, CGen_txt_right_recv_size_$num, MPI_CHAR, __hpat_node_id+1, 1, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                // std::cout<<"rank: "<<__hpat_node_id<<" received right "<<CGen_txt_right_recv_size_$num<<std::endl;
            }
            
            if(__hpat_node_id!=0)
            {
                MPI_Wait(&CGen_txt_MPI_request1_$num, &CGen_txt_MPI_status_$num);
                MPI_Wait(&CGen_txt_MPI_request2_$num, &CGen_txt_MPI_status_$num);
            }
            
            // if data needs to be sent right
            // still call MPI_Send if first character is new line
            int64_t CGen_txt_right_send_size_$num = 0;
            int64_t CGen_txt_tmp_curr_end_$num = CGen_txt_curr_end_$num;
            if(__hpat_node_id!=__hpat_num_pes-1 && CGen_txt_curr_end_$num>=CGen_txt_end_$num)
            {
                while(CGen_txt_tmp_curr_end_$num!=CGen_txt_end_$num-1)
                {
                    // -1 to account for \0
                    while(CGen_txt_buffer_$num[CGen_txt_buff_size_$num-CGen_txt_right_send_size_$num-1]!=\'\\n\') 
                        CGen_txt_right_send_size_$num++;
                    CGen_txt_tmp_curr_end_$num--;
                    // corner case, last line doesn't have \'\\n\'
                    if (CGen_txt_tmp_curr_end_$num!=CGen_txt_end_$num-1)
                        CGen_txt_right_send_size_$num++; // account for \n
                }
            }
            // send right
            if(__hpat_node_id!=__hpat_num_pes-1)
            {
                MPI_Isend(&CGen_txt_right_send_size_$num, 1, MPI_LONG_LONG_INT, __hpat_node_id+1, 0, MPI_COMM_WORLD, &CGen_txt_MPI_request1_$num);
                MPI_Isend(CGen_txt_buffer_$num+CGen_txt_buff_size_$num-CGen_txt_right_send_size_$num, CGen_txt_right_send_size_$num, MPI_CHAR, __hpat_node_id+1, 1, MPI_COMM_WORLD, &CGen_txt_MPI_request2_$num);
            }
            char* CGen_txt_left_buff_$num = NULL;
            int64_t CGen_txt_left_recv_size_$num = 0;
            // receive from left
            if(__hpat_node_id!=0)
            {
                MPI_Recv(&CGen_txt_left_recv_size_$num, 1, MPI_LONG_LONG_INT, __hpat_node_id-1, 0, MPI_COMM_WORLD,MPI_STATUS_IGNORE);
                CGen_txt_left_buff_$num = new char[CGen_txt_left_recv_size_$num];
                MPI_Recv(CGen_txt_left_buff_$num, CGen_txt_left_recv_size_$num, MPI_CHAR, __hpat_node_id-1, 1, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                // std::cout<<"rank: "<<__hpat_node_id<<" received left "<<CGen_txt_left_recv_size_$num<<std::endl;
            }
            if(__hpat_node_id!=__hpat_num_pes-1)
            {
                MPI_Wait(&CGen_txt_MPI_request1_$num, &CGen_txt_MPI_status_$num);
                MPI_Wait(&CGen_txt_MPI_request2_$num, &CGen_txt_MPI_status_$num);
                // std::cout<<"rank: "<<__hpat_node_id<<" sent right "<<CGen_txt_right_send_size_$num<<std::endl;
            }
            
            // int64_t total_data_size = (CGen_txt_end_$num-CGen_txt_start_$num)*CGen_txt_col_size_$num;
            // double *my_data = new double[total_data_size];
            int64_t CGen_txt_data_ind_$num = 0;
            
            char CGen_txt_sep_char_$num[] = \"\\n\";
            int64_t CGen_txt_curr_row_$num = 0;
            $t_typ * CGen_txt_data_arr = ($t_typ *)$arr.getData();
            while(CGen_txt_curr_row_$num!=CGen_txt_count_$num)
            {
                char* CGen_txt_line;
                if (CGen_txt_curr_row_$num==0)
                {
                    CGen_txt_line = strtok(CGen_txt_buffer_$num, CGen_txt_sep_char_$num);
                    if(CGen_txt_left_recv_size_$num!=0)
                    {
                        char *CGen_txt_tmp_line;
                        CGen_txt_tmp_line = new char[CGen_txt_left_recv_size_$num+strlen(CGen_txt_line)];
                        memcpy(CGen_txt_tmp_line, CGen_txt_left_buff_$num, CGen_txt_left_recv_size_$num);
                        memcpy(CGen_txt_tmp_line+CGen_txt_left_recv_size_$num, CGen_txt_line, strlen(CGen_txt_line));
                        CGen_txt_line = CGen_txt_tmp_line;
                    }
                }
                else if(CGen_txt_curr_row_$num==CGen_txt_count_$num-1)
                {
                    CGen_txt_line = strtok(NULL, CGen_txt_sep_char_$num);
                    if(CGen_txt_right_recv_size_$num!=0)
                    {
                        char *CGen_txt_tmp_line;
                        CGen_txt_tmp_line = new char[CGen_txt_right_recv_size_$num+strlen(CGen_txt_line)];
                        memcpy(CGen_txt_tmp_line, CGen_txt_line, strlen(CGen_txt_line));
                        memcpy(CGen_txt_tmp_line+strlen(CGen_txt_line), CGen_txt_right_buff_$num, CGen_txt_right_recv_size_$num);
                        CGen_txt_line = CGen_txt_tmp_line;
                    }
                }
                else
                {
                    CGen_txt_line = strtok(NULL, CGen_txt_sep_char_$num);
                }
                // parse line separately, not to change strtok's state
                for(int64_t i=0; i<CGen_txt_col_size_$num; i++)
                {
                    if(i==0)
                        CGen_txt_data_arr[CGen_txt_data_ind_$num++] = strtod(CGen_txt_line,&CGen_txt_line);
                    else
                        CGen_txt_data_arr[CGen_txt_data_ind_$num++] = strtod(CGen_txt_line+1,&CGen_txt_line);
         //           std::cout<<$arr[CGen_txt_data_ind_$num-1]<<std::endl;
                }
                CGen_txt_curr_row_$num++;
            }
            
            MPI_File_close(&dsrc_txt_file_$num);
            """
    end
    return s
end

function pattern_match_call_data_src_read(f::Any, v::Any, rf::Any, o::Any, arr::Any)
    return ""
end

function pattern_match_call_dist_h5_size(f::Symbol, size_arr::GenSym, ind::Union{Int64,SymAllGen})
    s = ""
    if f==:__hpat_get_H5_dim_size || f==:__hpat_get_TXT_dim_size
        @dprintln(3,"match dist_dim_size ",f," ", size_arr, " ",ind)
        s = ParallelAccelerator.CGen.from_expr(size_arr)*"["*ParallelAccelerator.CGen.from_expr(ind)*"-1]"
    end
    return s
end

function pattern_match_call_dist_h5_size(f::Any, size_arr::Any, ind::Any)
    return ""
end



function pattern_match_call(ast::Array{Any, 1})

    @dprintln(3,"hpat pattern matching ",ast)
    s = ""
    if length(ast)==1
         s = pattern_match_call_dist_init(ast[1])
    end
    if(length(ast)==4)
        s = pattern_match_call_dist_reduce(ast[1],ast[2],ast[3], ast[4])
        # text file read
        s *= pattern_match_call_data_src_open(ast[1],ast[2],ast[3], ast[4])
    end
    if(length(ast)==5)
        # HDF5 open
        s = pattern_match_call_data_src_open(ast[1],ast[2],ast[3], ast[4], ast[5])
        s *= pattern_match_call_data_src_read(ast[1],ast[2],ast[3], ast[4], ast[5])
        s *= pattern_match_call_dist_allreduce(ast[1],ast[2],ast[3], ast[4], ast[5])
    end
    if(length(ast)==3) 
        s = pattern_match_call_dist_h5_size(ast[1],ast[2],ast[3])
        s *= pattern_match_call_dist_bcast(ast[1],ast[2],ast[3])
    end
    if(length(ast)==8)
        s = pattern_match_call_kmeans(ast[1],ast[2],ast[3],ast[4],ast[5],ast[6],ast[7],ast[8])
    end
    if(length(ast)==12)
        s = pattern_match_call_linear_regression(ast[1],ast[2],ast[3],ast[4],ast[5],ast[6],ast[7],ast[8],ast[9],ast[10],ast[11],ast[12])
    end
    if(length(ast)==13)
        s = pattern_match_call_naive_bayes(ast[1],ast[2],ast[3],ast[4],ast[5],ast[6],ast[7],ast[8],ast[9],ast[10],ast[11],ast[12],ast[13])
    end
    return s
end


function from_assignment_match_dist(lhs::Symbol, rhs::Expr)
    @dprintln(3, "assignment pattern match dist ",lhs," = ",rhs)
    if rhs.head==:call && length(rhs.args)==1 && isTopNode(rhs.args[1])
        dist_call = rhs.args[1].name
        if dist_call ==:hps_dist_num_pes
            return "MPI_Comm_size(MPI_COMM_WORLD,&$lhs);"
        elseif dist_call ==:hps_dist_node_id
            return "MPI_Comm_rank(MPI_COMM_WORLD,&$lhs);"
        end
    end
    return ""
end

function from_assignment_match_dist(lhs::GenSym, rhs::Expr)
    @dprintln(3, "assignment pattern match dist2: ",lhs," = ",rhs)
    s = ""
    local num::AbstractString
    if rhs.head==:call && rhs.args[1]==:__hpat_data_source_HDF5_size
        num = ParallelAccelerator.CGen.from_expr(rhs.args[2])
        s = "hid_t space_id_$num = H5Dget_space(dataset_id_$num);\n"    
        s *= "assert(space_id_$num != -1);\n"    
        s *= "hsize_t data_ndim_$num = H5Sget_simple_extent_ndims(space_id_$num);\n"
        s *= "hsize_t space_dims_$num[data_ndim_$num];\n"    
        s *= "H5Sget_simple_extent_dims(space_id_$num, space_dims_$num, NULL);\n"
        s *= ParallelAccelerator.CGen.from_expr(lhs)*" = space_dims_$num;"
    elseif rhs.head==:call && rhs.args[1]==:__hpat_data_source_TXT_size
        num = ParallelAccelerator.CGen.from_expr(rhs.args[2])
        c_lhs = ParallelAccelerator.CGen.from_expr(lhs)
        s = """
            MPI_Offset CGen_txt_tot_file_size_$num;
            MPI_Offset CGen_txt_buff_size_$num;
            MPI_Offset CGen_txt_offset_start_$num;
            MPI_Offset CGen_txt_offset_end_$num;
        
            /* divide file read */
            MPI_File_get_size(dsrc_txt_file_$num, &CGen_txt_tot_file_size_$num);
            CGen_txt_buff_size_$num = CGen_txt_tot_file_size_$num/__hpat_num_pes;
            CGen_txt_offset_start_$num = __hpat_node_id * CGen_txt_buff_size_$num;
            CGen_txt_offset_end_$num   = CGen_txt_offset_start_$num + CGen_txt_buff_size_$num - 1;
            if (__hpat_node_id == __hpat_num_pes-1)
                CGen_txt_offset_end_$num = CGen_txt_tot_file_size_$num;
            CGen_txt_buff_size_$num =  CGen_txt_offset_end_$num - CGen_txt_offset_start_$num + 1;
        
            char* CGen_txt_buffer_$num = new char[CGen_txt_buff_size_$num+1];
        
            MPI_File_read_at_all(dsrc_txt_file_$num, CGen_txt_offset_start_$num, CGen_txt_buffer_$num, CGen_txt_buff_size_$num, MPI_CHAR, MPI_STATUS_IGNORE);
            CGen_txt_buffer_$num[CGen_txt_buff_size_$num] = \'\\0\';
            
            // make sure new line is there for last line
            if(__hpat_node_id == __hpat_num_pes-1 && CGen_txt_buffer_$num[CGen_txt_buff_size_$num-2]!=\'\\n\') 
                CGen_txt_buffer_$num[CGen_txt_buff_size_$num-1]=\'\\n\';
            
            // count number of new lines
            int64_t CGen_txt_num_lines_$num = 0;
            int64_t CGen_txt_char_index_$num = 0;
            while (CGen_txt_buffer_$num[CGen_txt_char_index_$num]!=\'\\0\') {
                if(CGen_txt_buffer_$num[CGen_txt_char_index_$num]==\'\\n\')
                    CGen_txt_num_lines_$num++;
                CGen_txt_char_index_$num++;
            }
        
            // std::cout<<"rank: "<<__hpat_node_id<<" lines: "<<CGen_txt_num_lines_$num<<" startChar: "<<CGen_txt_buffer_$num[0]<<std::endl;
            // get total number of rows
            int64_t CGen_txt_tot_row_size_$num=0;
            MPI_Allreduce(&CGen_txt_num_lines_$num, &CGen_txt_tot_row_size_$num, 1, MPI_LONG_LONG_INT, MPI_SUM, MPI_COMM_WORLD);
            // std::cout<<"total rows: "<<CGen_txt_tot_row_size_$num<<std::endl;
            
            // count number of values in a column
            // 1D data has CGen_txt_col_size_$num==1
            int64_t CGen_txt_col_size_$num = 1;
            CGen_txt_char_index_$num = 0;
            while (CGen_txt_buffer_$num[CGen_txt_char_index_$num]!=\'\\0\' && CGen_txt_buffer_$num[CGen_txt_char_index_$num]!=\'\\n\')
                CGen_txt_char_index_$num++;
            CGen_txt_char_index_$num++;
            while (CGen_txt_buffer_$num[CGen_txt_char_index_$num]!=\'\\0\' && CGen_txt_buffer_$num[CGen_txt_char_index_$num]!=\'\\n\') {
                if(CGen_txt_buffer_$num[CGen_txt_char_index_$num]==',')
                    CGen_txt_col_size_$num++;
                CGen_txt_char_index_$num++;
            }
            
            // prefix sum to find current global starting line on this node
            int64_t CGen_txt_curr_start_$num = 0;
            MPI_Scan(&CGen_txt_num_lines_$num, &CGen_txt_curr_start_$num, 1, MPI_LONG_LONG_INT, MPI_SUM, MPI_COMM_WORLD);
            int64_t CGen_txt_curr_end_$num = CGen_txt_curr_start_$num;
            CGen_txt_curr_start_$num -= CGen_txt_num_lines_$num; // Scan is inclusive
            if(CGen_txt_col_size_$num==1) {
                $c_lhs = new uint64_t[1];
                $c_lhs[0] = CGen_txt_tot_row_size_$num;
            } else {
                $c_lhs = new uint64_t[2];
                $c_lhs[0] = CGen_txt_tot_row_size_$num;
                $c_lhs[1] = CGen_txt_col_size_$num;
            }
            """
    end
    return s
end

function isTopNode(a::TopNode)
    return true
end

function isTopNode(a::Any)
    return false
end

function from_assignment_match_dist(lhs::Any, rhs::Any)
    return ""
end

end # module
